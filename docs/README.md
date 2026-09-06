# Documentation

Kind: reference

Pryvance documentation is organized by Diátaxis kind. The adopted shape is recorded in [doc-manifest.md](doc-manifest.md).

The explanation/reference design set describes the **feature-complete target architecture approved so far**. The roadmap sequences implementation; it is not the only place where later capabilities are defined.

## Tutorials — learning by doing
_(none yet)_

## How-to — task recipes
_(none yet)_

## Reference — facts and contracts
- [API contract](reference/api-contract.md) — target `/api/v1` application contract and conventions

## Explanation — why things are the way they are
- [Architecture](explanation/architecture.md) — C4 Context/Container/Component views, dynamic workflows, cross-cutting invariants
- [Domain model](explanation/domain-model.md) — feature-complete entities, relationships and global invariants
- [Planning and forecasting](explanation/planning-and-forecasting.md) — budgets, Household funding fairness, commitments, reserves, recurring cash flow, card payoff and scenarios
- [Wealth, records and tax](explanation/wealth-records-and-tax.md) — assets, investments, insurance, property, payroll, tax filing contexts and accountant exports
- [Integrations and automation](explanation/integrations-and-automation.md) — External Connections, AI/redaction, search, alerts, notifications and scheduled jobs
- [Security and privacy](explanation/security.md) — trust boundaries, purpose-aware authorization, tax-context privacy, AI/search/export/backup security
- [Roadmap](explanation/roadmap.md) — implementation sequencing for the already-defined target architecture

## Decisions and rationale
- [Architecture Decision Records](adr/README.md) — read the index first
- [Rationale index](rationale/) — local implementation reasoning referenced from code

## Vocabulary
- [CONTEXT.md](../CONTEXT.md) — canonical domain terms

## Product prototype
- [`prototype/pryvance-prototype.html`](../prototype/pryvance-prototype.html) — visual/product reference only; architecture/design docs are authoritative when they differ
