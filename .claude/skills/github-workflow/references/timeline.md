# Timeline check (two-tier)

Two tiers. The cheap tier runs every session, unconditionally. The full tier is a
deliberately high-bar exception, gated by enumerated hard conditions — not judgment
prose. Evaluate the gate from Orient's data only — the estimates already on the issues,
the dependency links already fetched, a coarse sum for condition 2; `history.sh` and
`timeline.sh` run only inside the full tier, never to decide whether to enter it. When
the data needed to test condition 2 is not already at hand, condition 2 is unmet and the
agent flags instead of fetching it.

## Cheap tier (always, at startup)

Inputs are limited to data Orient already fetched this session: each open milestone's
`due_on` and its start state (any issue assigned / in progress / merged). No recompute,
no scripts, no extra API calls beyond what Orient already made.

- Read the `due_on` on each pinned (started) milestone against today's date and its
  visible remaining open issues.
- If a due date looks off — clearly in the past with open work remaining, or a milestone
  that started well after an earlier one's projected end with no dependency explaining
  the gap — flag it as "due date looks off" in the brief.
- Default on any doubt: flag it and move on. Do not recompute, do not run scripts, do not
  guess a new date.

## Full tier (hard conditions only)

Inputs, scoped to this tier only (the cheap tier keeps its Orient-data-only
restriction above): each issue's `## Estimate` section, with its size class mapped to
cycle days via the calibration `plan-work` produced — or `plan-work`'s defaults when
there is no history yet; `blocked by` links, which are **issue-level**, not
milestone-level, and cross milestone boundaries; and today's date.

Run the full re-evaluation only when at least one of these holds:

1. The owner asked for it by name.
2. Estimates exist on the target's issues **and** a pinned milestone's remaining
   critical path overruns its `due_on` by more than 7 days.

The margin is the number 7, not "significant drift" — an agent must not interpret it.
Absent either condition, stay on the cheap tier and flag instead.

When the full tier runs, these placement rules apply:

- Milestones never carry `blocked by` links between each other — that link rots the
  moment one issue unblocks. Order comes from **issue** dependencies and, absent those,
  from the existing `due_on` order.
- A milestone that has started is **pinned** at its actual start (its first started
  issue); its projected end = start + remaining critical path at the observed parallelism.
- A milestone the owner just started in parallel is placed from **now**, overlapping;
  it does not push the running one.
- Milestones not started are laid out serially after the running ones unless issue
  dependencies force otherwise.
- Write `due_on` only where it changed by more than a day; note the change in the session
  log. Never edit a closed milestone.
- If placement is ambiguous (two unstarted milestones with no dependency between them and
  no prior order), ask the owner rather than guess.

The planning skill (`plan-work`) does the first placement when it files a milestone and
can be called again to re-sequence when priorities change; the full tier only keeps the
projection current between those calls, and only when triggered by one of the two hard
conditions above.
