# Architecture Decision Records

Numbered records of the decisions that shape Pryvance, using the MADR frame defined by the adopted design-docs standard.

**Read the index first.** Open only the ADRs whose status and subject you need.

## Amending an accepted ADR

Once Accepted, an ADR's Context, Decision Drivers, Considered Options, and Decision are not rewritten. A changed decision is recorded by a new ADR using the supersede/amend relationship headers.

## Index

Generated shape for the current ADR set; `scripts/docs/adr-index.sh --write` is authoritative.

<!-- adr-index:start -->
| # | Title | Status | Supersedes | Superseded by | Amends | Amended by | Decision |
|---|---|---|---|---|---|---|---|
| [0001](0001-adopt-design-docs-standard.md) | Adopt the design-docs documentation standard | Proposed | - | - | - | - | Pryvance adopts the owner's design-docs standard with C4 architecture, MADR ADRs, a root glossary,… |
| [0002](0002-use-modular-monolith-initially.md) | Use a modular monolith for the initial application | Proposed | - | - | - | - | Pryvance will begin as a modular ASP.NET Core monolith that serves the React build and hosts… |
| [0003](0003-model-household-finance-with-parties.md) | Model people and financial entities as Parties | Proposed | - | - | - | - | Pryvance will use Party as the canonical financial actor, with Person and Financial Entity as the… |
| [0004](0004-preserve-source-records-and-derive-financial-events.md) | Preserve immutable Source Records and derive linked Financial Events | Proposed | - | - | - | - | Pryvance will store immutable Source Records and explicit Source Relationships, then derive… |
| [0005](0005-use-deterministic-core-with-constrained-ai.md) | Keep financial truth deterministic and constrain AI to interpretation | Proposed | - | - | - | - | Pryvance will keep financial truth in deterministic application code and expose AI through… |
| [0006](0006-separate-visibility-from-ownership-and-coverage.md) | Separate visibility, filing access, ownership and data coverage | Proposed | - | - | - | - | Pryvance will model ownership, Visibility Policy, Tax Filing Context access and Coverage as… |
| [0007](0007-encrypt-backups-before-offsite-storage.md) | Encrypt offsite recovery data before storage | Proposed | - | - | - | - | Pryvance will encrypt/authenticate all recovery data locally before it leaves trusted storage and… |
| [0008](0008-separate-economic-scopes-from-parties-and-assets.md) | Separate Economic Scopes from Parties and Assets | Proposed | - | - | - | - | Pryvance will separate actors, owned economic items, and allocation/reporting targets into Party,… |
| [0009](0009-preserve-effective-time-and-knowledge-time.md) | Preserve effective time and knowledge time | Proposed | - | - | - | - | Pryvance will preserve both effective time and knowledge/audit time for historically meaningful… |
| [0010](0010-reconcile-household-funding-without-default-debt.md) | Reconcile Household funding without default interpersonal debt | Proposed | - | - | - | - | Pryvance will represent shared-funding fairness through Funding Reconciliation. It compares target… |
| [0011](0011-use-one-household-root-per-installation.md) | Use one Household root per Pryvance installation | Proposed | - | - | - | - | A Pryvance installation will have exactly one Household root. It may contain any number of People,… |
| [0012](0012-model-external-connections-by-capability.md) | Model external connections by capability and authentication method | Proposed | - | - | - | - | Pryvance will model an External Connection with provider, owner, authentication method, credential… |
| [0013](0013-use-postgresql-durable-job-queue.md) | Use a PostgreSQL-backed durable job queue and transactional outbox | Proposed | - | - | - | - | Pryvance will use PostgreSQL as the initial durable job queue and transactional outbox. Workers… |
| [0014](0014-use-tiered-content-addressed-object-storage.md) | Use tiered content-addressed object storage with configurable recovery targets | Proposed | - | - | - | - | Pryvance will identify original evidence by content hash and store one or more Object Replicas on… |
| [0015](0015-preserve-native-money-and-derive-reporting-currency.md) | Preserve native money and derive reporting-currency values | Proposed | - | - | - | - | Pryvance will preserve every native Money observation and derive reporting-currency values… |
<!-- adr-index:end -->
