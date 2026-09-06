# ADR-0009: Preserve effective time and knowledge time

Status: Proposed
Date: 2026-09-06

## Context

Pryvance must both recompute historical analysis using newly discovered facts and explain what recommendation/calculation was made with the information available at an earlier date.

Examples include annual Household funding fairness after a later W-2 establishes actual wages, corrected investment history, late receipts, property valuations, and changed plan/policy configuration. A single mutable `current value` or one effective-date field cannot answer both `what applies when` and `what did Pryvance know when`.

## Decision Drivers

- Reconstruct which plans/ownership/policies were effective for a financial period.
- Preserve what information supported a prior recommendation.
- Allow retrospective recalculation with newly discovered evidence.
- Avoid rewriting historical plan state when future configuration changes.
- Keep the model lighter than full event sourcing.

## Considered Options

1. **Effective-dated versions plus knowledge/audit timestamps** — supports retrospective truth and historical audit without full event sourcing; adds temporal query complexity.
2. **Only effective dates** — reconstructs policy periods but cannot reproduce prior knowledge/recommendations after late facts arrive.
3. **Only current values plus Audit log** — easy writes; historical analytical queries become difficult/inconsistent.
4. **Full event sourcing** — maximal history; substantially more implementation complexity than required.

## Decision

Pryvance will preserve both effective time and knowledge/audit time for historically meaningful facts, relationships, plans, and recommendations.

- **effective time** — when a fact, ownership relationship, plan version, or policy applies in the modeled financial world;
- **knowledge/audit time** — when Pryvance learned, derived, recommended, verified, or changed it.

Historically meaningful plans/relationships use effective-dated versions. Derived recommendations and mutable interpretation changes produce Audit Entries or equivalent knowledge-time records sufficient to reconstruct the inputs/calculation version used.

## Consequences

- Pryvance can answer `what would the fair 2026 split be using everything known now?` separately from `what did Pryvance recommend on June 1, 2026?`.
- New evidence may change retrospective analytics without erasing the prior recommendation.
- Budget/Funding Plan changes do not retroactively rewrite prior effective plans.
- Ownership and valuation attribution can be reconstructed for prior dates.
- Temporal queries/testing are more complex and require explicit APIs/query semantics such as `asOf` and `knowledgeAt`.
