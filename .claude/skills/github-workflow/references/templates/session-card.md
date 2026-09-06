# Session Card Template

Written to `<scratch>/session-card.md` at startup and re-read at every checklist's
`card-read` step and after every compaction — see
[SKILL.md](/.claude/skills/github-workflow/SKILL.md) step 0 and
[platform-claude.md § Post-compaction
re-read](/.claude/skills/github-workflow/references/platform-claude.md#post-compaction-re-read),
both linked repo-root-relative per the convention below.
Every line below is a binding (`key: value`), a literal value, or a pointer (`see
<file>#<anchor>`) — never a restated rule: a rule paraphrased here drifts from its
source the moment that source changes, while a pointer cannot drift because it names
nothing but where to look.

All pointers below are **repo-root-relative**, since the card lives in `<scratch>`
outside the repository. Inside a markdown link the path takes a leading `/`
(`[SKILL.md](/.claude/skills/github-workflow/SKILL.md)`) so GitHub resolves it; inside
the fenced block it is bare (`.claude/skills/github-workflow/references/...`), resolved
from the repo checkout the reading session already has as its working directory.

```markdown
# Session card — <UTC timestamp>

## Identity
repo: <owner/repo>
target: <issue|epic|milestone|triage|next>
mode: <solo | orchestrated serial | orchestrated parallel>
horizon: <interactive | overnight>
claim: <claim id — see .claude/skills/github-workflow/references/claims.md § Format>
session id: <harness session id, or self-minted token>
log path: <scratch>/session.jsonl

## Board ids
project: <project node id>
Status field: <field id> — Triage <opt id> · Backlog <opt id> · Ready <opt id> ·
  In progress <opt id> · In review <opt id> · Done <opt id>
Verified field: <field id> — n/a <opt id> · pending-live <opt id> ·
  live-verified <opt id> · live-failed <opt id>
Claimed by field: <field id>
see docs/process/work-tracking.md

## Commands
test: see docs/process/testing.md
ci: see docs/process/testing.md —
  "none" where that doc names no CI workflow
lint: see docs/process/testing.md
sanitize: see docs/process/testing.md (or docs/testing.local.md, untracked) —
  "none declared" where neither names a sanitize rule

## Thresholds
round cap, executable-code: 3
round cap, test-only/doc-only: 2
stale-claim window: 24h, no live agent/PR activity — see
  .claude/skills/github-workflow/references/claims.md#taking-an-id-at-session-start
maintenance cadence: session start, every resume, before each parallel wave or every
  three serial issues, on "morning cleanup" — see
  .claude/skills/github-workflow/references/maintenance.md
host thresholds: see docs/process/maintenance.md

## Routing (tier + Claude example, verbatim from
  .claude/skills/github-workflow/references/orchestration.md's Routing table)
Implementer: mid (Claude: Sonnet)
Fix round 1, not design-shaped: mid (Claude: Sonnet)
Fix round ≥2: large (Claude: Opus)
Fix round, final-entering: large (Claude: Opus)
Fix round, reviewer-labelled design-shaped: large (Claude: Opus)
Review, default: large (Claude: Opus)
Review round 1 of a doc-only PR: mid (Claude: Sonnet)
Review, residual-only final round: mid (Claude: Sonnet)
Merge-verification: mid (Claude: Sonnet)
Rebase: mid (Claude: Sonnet)
Calibrator: mid (Claude: Sonnet)
Validation agent: large (Claude: Opus)
Other helpers: small (Claude: Haiku)
see .claude/skills/github-workflow/references/orchestration.md#routing-table

## Paths
evidence root: <scratch>/evidence/issue<N>/
archive location: see docs/process/work-tracking.md's `Session-log archive:` line —
  "not configured" where that line is absent
worktree root: see docs/process/worktrees.md

## Checklists (canonical slugs, in order; `card-read` first in every non-startup list)
startup: log-open, quiet-mode, target-mode-horizon, orient, agent-defs, session-card,
  concurrent-check, claim, timeline-sanity, readiness-gate, maintenance, heartbeat
triage: card-read, claim, provenance, dedupe, labels-complete, home, chain,
  priority-order, batch, board
dispatch: card-read, pick, claim-stamp, worktree, board, model, preflight,
  evidence-key, manifest, dispatch
report-handling: card-read, report, self-corrections, deferrals, verdict, relay, board,
  metrics, epic-event, cleanup, claim-refresh (last four: merge outcome only)
close: card-read, save-log, brief, claims-released, heartbeat-off, handoff
see .claude/skills/github-workflow/references/formats/session-log.md (source of
  record for all five lists)

## Where to look
design record: <epic #N's design-decision comment, or "none for this target">
epic threads: <epic #N — events in comments>
process docs: docs/process/*.md, docs/process/*.local.md (untracked)
agent rules: .claude/skills/github-workflow/references/agent-rules.md
platform notes: .claude/skills/github-workflow/references/platform-claude.md
```
