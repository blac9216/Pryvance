# Platform: Claude Agent SDK

This is the single place the workflow suite names a harness. Everything else in
`github-workflow` and `github-pr-review` stays repo-, language- and harness-agnostic —
process, not platform. When you are running under a different harness, read the
"Porting this suite" paragraph below, supply its six items, and nothing else in either
skill needs to change.

## Contents

- [Porting this suite](#porting-this-suite)
- [Tier → model mapping](#tier--model-mapping)
- [Subagent type pinning and model precedence](#subagent-type-pinning-and-model-precedence)
- [Task-notification semantics and the auto-backgrounding trap](#task-notification-semantics-and-the-auto-backgrounding-trap)
- [`tools:` allowlist semantics](#tools-allowlist-semantics)
- [Resuming a finished agent](#resuming-a-finished-agent)
- [Post-compaction re-read](#post-compaction-re-read)
- [Orchestrator is local-only](#orchestrator-is-local-only)

## Porting this suite

A different harness needs to supply six things before this skill suite's process
guidance transfers unchanged:

1. **A subagent mechanism with per-role definitions and model pinning** — something
   equivalent to a `subagent_type` that resolves to a fixed role definition, with the
   model set explicitly at dispatch time rather than inherited.
2. **A way to deny tools per role** — an allowlist or denylist mechanism strict enough
   that a role's dispatch prompt is the only source of what it can touch, so "no
   subagents" and similar rules are enforceable rather than aspirational.
3. **A background-task completion signal, or its documented absence.** Either the
   harness notifies a dispatched agent when a backgrounded job finishes, or it plainly
   does not — the workflow suite's bounded-wait recipe exists specifically because this
   harness's answer is "does not" for subagents (see below).
4. **A compaction behaviour.** Something must happen when an agent's context fills:
   automatic summarisation, a hard cutoff, or nothing at all. Whatever it is, the
   process's "record state before compaction" rule
   ([SKILL.md](../SKILL.md)) assumes state can be lost at an unpredictable moment and
   writes defensively; a harness with no compaction at all makes that rule cheap
   insurance rather than a requirement.
5. **A local CLI for the orchestrator's scripts.** The `github-workflow/scripts/`
   tooling shells out to `gh`; the orchestrator role is declared local-only for this
   reason (see [Orchestrator is local-only](#orchestrator-is-local-only)) and a ported
   harness needs an equivalent local shell with an equivalent CLI, not just cloud-side
   API access.
6. **An interval/scheduling primitive for orchestrator self-resume.** The heartbeat is
   unconditional on every horizon, so a ported harness must supply some mechanism that
   wakes the orchestrator on a fixed interval without an outstanding human turn — on
   this harness, `CronCreate`.

## Tier → model mapping

This is the one place in the suite a model name is canonical. Everywhere else — the
Routing table in [orchestration.md](orchestration.md), the helper-tier rule in
[agent-rules.md](agent-rules.md) — names a size tier and, for readability, an
illustrative Claude example in parentheses; that parenthetical is not the source of
truth, this table is.

| Tier | Claude model |
|---|---|
| small | Claude Haiku |
| mid | Claude Sonnet |
| large | Claude Opus |

Repointing this table to a different model family is the entire cost of moving the
routing scheme to a new Claude generation, and — combined with the rest of this file —
most of the cost of moving it to a different harness's models entirely.

## Subagent type pinning and model precedence

Every dispatched role is pinned to a fixed `subagent_type`. This suite defines six of
them — `workflow-implementer`, `workflow-fix`, `workflow-reviewer`, `workflow-rebase`,
`workflow-merge-verifier` and `workflow-calibrator` — and each resolves to
`.claude/agents/workflow-<role>.md` when that definition is present in the repo; the
`agent-defs` startup check is what verifies the resolution, so a type whose definition
has not landed yet is caught at startup rather than at dispatch. A `subagent_type`
selects the role's tool allowlist, its standing rules **and** its default model — the
`model:` key in the definition's frontmatter — which a dispatch-time `model` overrides.

The harness resolves a dispatched agent's model in this order (Claude Code docs,
[Subagents → Choose a model](https://code.claude.com/docs/en/sub-agents#choose-a-model)):

1. the `model` passed with the dispatch itself;
2. the role definition's `model:` frontmatter, where the value `inherit` selects the
   parent session's model;
3. the configured default subagent model (`CLAUDE_CODE_SUBAGENT_MODEL`, when set);
4. the parent session's own model.

Every definition under `.claude/agents/` carries the frontmatter key today —
`workflow-reviewer` is `opus`, the rest `sonnet` — so for those roles a dispatch that
omits `model` resolves at level 2, not at level 4.

**Always set `model` explicitly at dispatch.** This is the canonical statement of that
rule; every other file in the suite points here. Two reasons. It makes the tier the
Routing table in [orchestration.md](orchestration.md#routing-table) names authoritative
for the round, rather than whatever a definition happens to default to — the table
varies a role's tier by round, and frontmatter cannot. And it is the only level of the
chain that cannot fall through: a definition that carries no `model:` key, or a
`subagent_type` that fails to resolve to a definition at all, drops to level 3 or, with
no configured default subagent model, to level 4 — the orchestrating session's own
model, the premium tier — silently, with nothing in the dispatch or the agent's report
saying it happened. That is the "model inheritance"
entry in [failure-modes.md](failure-modes.md#observed-failure-modes-general). Resolve
the model to dispatch from the [tier → model mapping](#tier--model-mapping) above, using
the tier the Routing table names for that role and round.

## Task-notification semantics and the auto-backgrounding trap

The harness promises the top-level session a notification when a background task it
started completes. That promise does not extend to a dispatched subagent: a subagent
that ends its turn expecting to be woken by such a notification never is, no matter how
long the backgrounded job runs, because no notification channel reaches a subagent at
all. The agent looks alive — it is simply waiting on an event that cannot arrive. This
is the mechanism behind the "subagent auto-backgrounding notification trap" entry in
[failure-modes.md](failure-modes.md#observed-failure-modes-general).

The bounded-wait recipe every dispatched role follows — detach the job, poll for a
sentinel with a single bounded `timeout` call per attempt, never idle-wait — is the
mitigation, and it is stated once, canonically, in
[agent-rules.md](agent-rules.md#bounded-wait-recipe). This section explains why the
recipe is necessary; it does not restate the recipe itself.

## `tools:` allowlist semantics

A role definition's `tools:` (or `disallowedTools:`) frontmatter is that role's entire
tool surface for the whole of its run — nothing reachable through some other path
around it. This is what makes "no subagents" enforceable for a role whose definition
denies the `Agent` and `Task` tools outright: it is not a request the role could
disregard, it is a tool that is simply absent.

One nuance does not work the way it first appears: `Agent(<type>)` allowlist syntax
restricts *which* subagent types may be spawned only when it appears on an agent
running as the harness's main thread. Inside a subagent definition — which is how every
role in this suite is dispatched — a listed `Agent` tool is unrestricted regardless of
any `(<type>)` qualifier, so a role permitted `Agent` at all can, mechanically, spawn
any type. The helper-tier rule in
[agent-rules.md](agent-rules.md#helper-tier) is therefore the whole control on which
helper a role may spawn — enforced by the role reading and following the rule, not by
the tool surface — and no role definition may claim its allowlist enforces that
restriction for it.

`Skill` and `TodoWrite` are gated the same way as every other tool: a role whose
`tools:` line does not list them cannot invoke them, and no definition in this suite
lists either. A skill therefore reaches a dispatched role as a **file it reads** —
`Read` on `.claude/skills/<skill>/SKILL.md`, followed step by step — never as a `Skill`
invocation, and a dispatch prompt that puts a role under a skill names that file path
rather than asking for an invocation the role's surface cannot make. Widening a
definition's `tools:` to admit `Skill` would hand that role every skill in the repo, not
the one its dispatch names; reading the one file is the narrower grant and the one this
suite uses.

## Resuming a finished agent

A subagent that has returned can be continued by sending it another message addressed by
its agent id or name: it wakes with its transcript intact — the branch it read, the
files it edited, the findings it posted. The orchestrator holds the id from the
dispatch's task notification. Two uses are sanctioned: restarting a stalled agent
([orchestration.md § Restarting a stalled
agent](orchestration.md#restarting-a-stalled-agent)), and the **relay** in
[orchestration.md's Report-handling
checklist](orchestration.md#report-handling-checklist), where the implementer is resumed
once with the reviewer's `minor` in-diff findings and the reviewer once with the head
the implementer pushed, inside one review round.

Three limits on the relay, and the fallback for each:

- **Local-only.** A resume reaches an agent dispatched from this session on this
  machine. In the cloud sandbox, or after the orchestrating session itself has restarted,
  the finished agent's transcript is not reachable — the fallback is the fix-round
  dispatch on the relayed findings and a fresh reviewer at the same round number
  ([orchestration.md's Report-handling checklist](orchestration.md#report-handling-checklist),
  `relay`); the orchestrator records `fallback: true` on the `relay` event.
- **Once per round, on purpose.** The harness places no limit on how many times an agent
  can be resumed; the process does (`github-pr-review` Step 7 § Relay), so that a round
  can never become an open-ended conversation between two agents that nobody dispatched
  fresh.
- **Not for fix rounds.** Outside the relay, the workflow still dispatches a fresh
  fix-round agent every round rather than resuming the implementer, unconditionally. The
  reasons are process reasons, not a harness limitation, and they are recorded once in
  [orchestration.md](orchestration.md#routing-table).
  Whatever a ported harness's own resumability story turns out to be, it changes neither
  the relay's bound nor the fix-round rule, because neither was chosen for a
  harness-imposed reason.

Dispatch templates keep their literal `Dispatch with subagent_type: workflow-<role>`
line; only this file describes the mechanism behind it.

## Post-compaction re-read

This harness does not stop an agent whose context grows long: it summarises the
conversation so far and continues in a fresh window carrying that summary plus whatever
tail was too recent to be summarised. Nothing else crosses over — file contents, command
output, issue bodies and dispatch detail read before the compaction survive only as much
of the summary as covers them, and only if they were written down somewhere durable. The
moment is unpredictable from inside the agent, which is why the process's "record state
before compaction" rule ([SKILL.md](../SKILL.md)) has an agent push pending state out to
event comments, board moves and the log rather than holding it in the window.

The re-read hook is the session card: the first thing a session does in its fresh window
is re-read its own card, which restores the pointers a summary flattens away — the
claimed epic, the PRs in flight, the round counts, and where the log lives.

The card itself is `<scratch>/session-card.md`, written at startup from
[references/templates/session-card.md](templates/session-card.md) — facts and pointers
only, regenerated wholly whenever target or mode changes, never patched. Re-reading it
is the reflex compaction demands: a card kept continuously in view survives a
summarisation pass that a plan or a scratch note does not, because the harness carries
forward only what the summary chose to keep, and the summary did not choose on the
agent's behalf. The `card-read` slug — the first item of every logged checklist other
than startup itself — is how the session log shows the re-read actually happened,
rather than being assumed from the fact that the card exists on disk.

## Orchestrator is local-only

The orchestrator role is declared local-only: its scripts under `github-workflow/scripts/`
shell out to the `gh` CLI, and there is no `gh` binary in a cloud sandbox. Reviewers and
implementers, by contrast, have a documented cloud path for every operation they need —
see [github-tools.md](github-tools.md), which is the canonical environment mapping (`gh`
CLI vs. GitHub MCP tools) and is not duplicated here. An orchestrating session therefore
always runs on a machine with a working local CLI; a reviewer or implementer dispatched
from that session may run in the cloud sandbox.
