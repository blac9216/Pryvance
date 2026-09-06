# Bug Issue Template

Use when something is broken or not working as expected. Apply the `bug` label
plus a `severity:*` label, a `size:*` label, and at least one `area:*` label at
creation.

```markdown
## Description
What is broken and how it manifests. Include exact error messages or log output.

## Discovery
How and when this was discovered. What operation or test triggered it.
Include the sequence of events that led to finding the problem.

## Root Cause (if known)
Technical explanation of why it happens. If unknown, state what has been investigated so far.

## Affected Files
| File | Relevance |
| ---- | --------- |
| `path/to/file` | Why this file is involved |

## Impact
What is affected (features, output, user experience, other components).

## Possible Fixes
- Option A: Description of approach and trade-offs
- Option B: Alternative approach if applicable

## Done when
- [ ] The described failure no longer reproduces: <the exact command/test the reviewer runs>
- [ ] Root cause addressed, with a regression test

## Home
`Milestone: <story>` when it sits directly under a story — or `Part of #<epic>` — or
`standalone` (board only). Deferred items: per SKILL.md's Deferred Items rule — milestone,
no epic parent, a `Spawned by #<N>` (discovering issue) or `Spawned by PR #<P> round
<R>` (review finding) line, followed by a required `Unit:` line, in place of a
parent link, `deferred` + `concern:*` + `area:*`.

`Unit:` sits on its own line in this section, immediately after the `Spawned by` line,
and carries exactly one of three values: a **repo-relative file path**, a
**repo-relative directory path** ending in `/`, or an **`area:*` label** when the
finding has no path at all. It is required on a deferred item and appears on no other
issue — it is only ever paired with provenance. `batch-deferred.sh` groups residual work
by it, triage normalises it (`maintenance.md` § 1 step 9), and the parked dup-scan
(github-pr-review SKILL.md Step 8) matches new findings against it, so the whole
contract — the lexical form a parser may rely on, how to choose the value when a finding
touches several files, and what each reader does when the line is missing — is stated
once in SKILL.md's Deferred Items rule and is not restated here. Rendered, the two
provenance lines are separate lines, not a prose run-on:

```text
## Home
Milestone: <story>. No epic parent.
Spawned by PR #412 round 2
Unit: .claude/skills/github-workflow/scripts/batch-deferred.sh

Labels: bug, deferred, concern:reliability, area:skills.
```

Labels at filing: type, ≥1 `area:*`, `priority:*` if known. Sequencing (dependencies, final priority) is the
orchestrator's at triage — do not guess it here.

## Estimate
Size: S (≤100 net LOC) | M (≤400) | L (must be split before filing). Set the matching
`size:s`/`size:m`/`size:l` label at filing, next to `area:*` — the label is the
machine-readable marker a script reads; this line is the argument behind it. A
non-code issue (no net LOC — e.g. a docs-only change) sizes by review effort instead: S
= a single file or section, readable in one pass; M = several files/sections needing
cross-checking; L = a structural rewrite spanning most of a document set — split before
filing, same as code. `size:l` on a filed issue is a triage tripwire, not a resting
state: since L already means "must be split before filing", one appearing at all means
something slipped past the filer, and `maintenance.md`'s `labels-complete` triage step
splits it into right-sized siblings (or an epic plus several S/M children) before it
leaves Triage, rather than letting it ride to dispatch as filed. Est. cycle: <days, from
the calibration table for this area × size, or the default>. Est. completion: <date,
from sequencing — rough; the workflow re-projects at each session start>.

## Verified expectation
`n/a` — review proves everything here | `pending-live` — <what only the real stack can
prove>. The PR repeats this line; the reviewer sets the board field from it.
```
