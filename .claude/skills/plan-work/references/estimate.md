# Estimation

Estimates exist to place work on the roadmap, not to hold anyone to a number. They are
per issue; everything else is derived.

## Calibration — `scripts/history.sh`

Read-only, GET-only. Defaults to the last 90 days (`--since` to widen; the full history of a busy repository takes about an hour and approaches the hourly API limit). `--adoption-date` tags records pre/post the workflow adoption so the table can be filtered once the post-adoption sample is large enough. For every closed issue with a merged PR it collects: start (`start_source` = `assigned` from the first `assigned` timeline event before the merge → `pr-open` → `issue-created`; a `first-commit` source is planned once branch data is joined), PR opened,
merged, review rounds (a **round** is one `<!-- review {…} -->` footer on the PR;
footer-less PRs are excluded from this count, not counted as zero), findings per round,
additions/deletions/files, labels (area, type, severity, priority), parent epic,
milestone, the issue's `size:*` label if it has one, the **metrics closing comment** if
one exists, and deferred issues the PR spawned (cross-references). Missing fields are
recorded as missing, and every aggregate states its sample size — a repository without
the workflow yields a thinner table, not a wrong one.

Output (scratch, JSON + a markdown view): per **area × size** bucket, `n`, p50/p80
cycle hours (start→merged; agent cycles are sub-day), p50 rounds, first-pass approval rate, median LOC. Size for
historical issues comes from the issue's `size:*` label when present (never the
Estimate section's prose), else from actual net LOC (S ≤100, M ≤400, L >400). A second
table compares **estimated vs actual** where both exist — that is the calibration
signal the owner asked for.

Defaults when a bucket has `n < 3`: fall back to the area's all-sizes median, then the
repository median, then the built-in defaults (S 2h · M 6h · L 16h, 1.5 rounds) — and say
which fallback was used on every estimate.

## Per-issue estimate

**Step 0 — delivered-scope check (#202), for an already-filed issue only** (a brand-new
issue has nothing to check yet): before sizing or re-sizing, run
`git log --oneline --grep="#<N>"` and `gh pr list --search "<N>" --state merged` — or,
authoritatively, `scripts/delivered.sh --repo owner/name --issues <N>`, which reports the
linked closing PRs *and* the cross-referenced merged PRs with net LOC in one GET-only
request. Its **Net LOC** is `|additions − deletions|` summed over the matched merged
PRs — the same absolute-net convention `history.sh` records per PR — so a PR that adds
and removes in equal measure contributes 0, and a pure deletion contributes its size.
Prefer the script: a title/body search misses a merged PR that references the
issue only from a commit message, a review comment or a linked branch, and measured on
2026-09-06 it missed 2 of 5, 3 of 5 and 1 of 1 such PRs on three real issues (#202). If
a merged PR already references the issue, subtract its scope before
estimating the remainder: nothing left → close as delivered, never split or re-estimate;
an S/M remainder → re-size to that bucket and record it below, never split; only an L
remainder still needs `decompose.md`'s split gate.

Size class from the design: the files it touches, whether it adds a migration, a UI
screen, a new transport — anything that has historically meant more rounds. Write the
**Estimate** section: `Size · est. cycle (bucket, n, fallback if any) · est. completion`.
When step 0 found non-zero delivered scope, add a line: `Delivered so far: PR #… (n
LOC)` — comma-join multiple PR numbers on one line with one shared LOC total.
Completion comes from sequencing ([timeline.md](timeline.md)), is rough, and is
re-projected by github-workflow at every session start.
