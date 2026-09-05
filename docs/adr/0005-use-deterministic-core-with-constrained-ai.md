# ADR-0005: Keep financial truth deterministic and constrain AI to interpretation

Status: Proposed
Date: 2026-09-05

## Context

Pryvance will use a local OpenAI-compatible model through LM Studio for merchant normalization, ambiguous classification, receipt/document interpretation, semantic search, and financial analysis. The same system also performs deduplication, reconciliation, budgeting, allocations, privacy enforcement, and financial calculations where nondeterministic behavior would be unsafe and difficult to audit.

## Decision Drivers

- Keep financial totals and reconciliation reproducible.
- Allow local AI to add value where ambiguity is genuinely semantic.
- Prevent unrestricted model access to household financial data and SQL.
- Make every automated result explainable and reviewable.
- Permit AI providers/models to change without changing core domain behavior.

## Considered Options

1. **Deterministic core plus constrained AI tools/structured outputs** — auditable and replaceable; requires explicit tool and validation design.
2. **AI-first agent with broad database/tool access** — flexible and fast to prototype; weak correctness, authorization, and reproducibility guarantees.
3. **No AI in the product** — simplest trust model; gives up useful extraction, classification, semantic search, and explanation capabilities.

## Decision

Pryvance will use deterministic application code for financial truth and expose AI only through bounded inputs, structured outputs, and constrained application tools; AI cannot directly own arithmetic, deduplication, authorization, reconciliation, or unrestricted database mutation.

## Consequences

- Model outputs are validated before they affect derived records.
- Low-confidence or non-reconciling output creates Review Items.
- Analytics exposed to AI are implemented as typed query tools rather than raw SQL generation.
- The AI provider is abstracted behind an OpenAI-compatible interface so LM Studio can be replaced.
- Some AI-assisted features require more application code than an unrestricted agent approach.
