# Documentation

Kind: reference

Pryvance documentation follows Diátaxis and the adopted shape in [doc-manifest.md](doc-manifest.md).

The explanation/reference design set describes the **feature-complete target architecture approved so far**. The roadmap sequences implementation; later-phase capabilities are already part of the target design.

## Tutorials — learning by doing
_(none yet)_

## How-to — task recipes
_(none yet)_

## Reference — facts and contracts
- [API contract](reference/api-contract.md) — target `/api/v1` financial/application contract
- [Operational and integration API](reference/operations-api.md) — storage, jobs, AI/provider setup, mail rules, FX and detailed recovery APIs
- [Target PostgreSQL data model](reference/data-model.md) — relational blueprint, constraints and ER diagrams
- [Alert catalog](reference/alert-catalog.md) — stable core Alert types/default trigger semantics

## Explanation — why things are the way they are
- [Architecture](explanation/architecture.md) — C4 Context/Container/Component plus dynamic flows/invariants
- [Domain model](explanation/domain-model.md) — target domain relationships/invariants
- [Planning and forecasting](explanation/planning-and-forecasting.md) — budgets, funding fairness, reserves, recurring cash flow, card payoff and scenarios
- [Wealth, records and tax](explanation/wealth-records-and-tax.md) — investments, Assets, property, insurance, payroll and U.S. tax workspace
- [Integrations and automation](explanation/integrations-and-automation.md) — External Connections, AI/redaction, search, Alerts and Scheduled Insights
- [Storage lifecycle and recovery](explanation/storage-and-recovery.md) — hot/cold object tiers, Archive Packs, rehydration, independent database/object recovery
- [Background jobs](explanation/operations-and-jobs.md) — PostgreSQL queue/outbox, leases, retries, schedules and concurrency
- [Security and privacy](explanation/security.md) — trust boundaries and purpose-aware privacy/security
- [Roadmap](explanation/roadmap.md) — implementation sequencing for the already-defined target architecture

## Decisions and rationale
- [Architecture Decision Records](adr/README.md) — read the index first
- [Rationale index](rationale/) — local implementation reasoning referenced from code

## Vocabulary
- [CONTEXT.md](../CONTEXT.md) — canonical domain terms

## Product prototype
- [`prototype/pryvance-prototype.html`](../prototype/pryvance-prototype.html) — visual/product reference; design docs are authoritative when they differ
