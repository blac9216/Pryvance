# ADR-0005: Keep financial truth deterministic and constrain AI to interpretation

Status: Proposed
Date: 2026-09-05

## Context

Pryvance uses AI for semantic work such as merchant normalization, ambiguous classification, receipt/document extraction, anomaly explanation, semantic search, tax-record assistance, and financial analysis. The same product also performs deduplication, reconciliation, authorization, budgeting, funding fairness, forecasting, net-worth traversal, and tax-sensitive organization where nondeterministic behavior would be unsafe and difficult to audit.

The expected common deployment uses local LM Studio/OpenAI-compatible inference, but the architecture should not prevent an operator from attaching another local or remote provider later.

## Decision Drivers

- Keep financial totals, reconciliation and plan calculations reproducible.
- Allow AI to add value where ambiguity is genuinely semantic.
- Permit AI provider/model replacement without changing domain behavior.
- Prevent unrestricted model access to Household data and SQL.
- Minimize sensitive-data exposure, especially if a remote provider is configured.
- Make automated results explainable, evidence-linked and reviewable.

## Considered Options

1. **Provider-neutral deterministic core + constrained AI tools/structured outputs + redaction gateway** — auditable, privacy-aware and replaceable; requires explicit tooling/validation.
2. **Local-only AI hard-coded to LM Studio** — strongest product-level locality promise; unnecessarily restricts future operator choice.
3. **AI-first agent with broad DB/tool access** — flexible/fast to prototype; weak correctness, privacy, authorization and reproducibility.
4. **No AI** — simplest trust model; gives up useful extraction/search/explanation capabilities.

## Decision

Pryvance will keep financial truth in deterministic application code and expose AI through provider-neutral interfaces, bounded/typed application tools, structured outputs, authorization-before-retrieval, and a redaction/minimization gateway.

Local AI is an expected default but not an architectural restriction. Remote AI requires explicit operator configuration/disclosure that selected authorized data may leave the local environment.

Sensitive values such as SSNs, full account/policy identifiers, credentials and recovery secrets are redacted by default. Stable placeholders may preserve semantic relationships where useful.

AI cannot directly own arithmetic, deduplication, authorization, reconciliation, funding/budget calculations, net-worth deduplication, backup cryptography, final tax treatment, or unrestricted database mutation.

## Consequences

- Model outputs are validated before affecting derived records.
- Low-confidence/non-reconciling output becomes candidate fact or Review Item.
- Analytics exposed to AI are typed tools, not raw SQL generation.
- Tool authorization cannot be widened by model-selected arguments.
- Search/semantic retrieval follows Visibility Policy before data enters AI context.
- Provider configuration can support LM Studio or other adapters without changing domain contracts.
- Remote-provider use remains possible but defaults to minimized/redacted context and is auditable/configurable.
- Some AI-assisted features require more deterministic application code than an unrestricted agent design.
