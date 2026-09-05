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
| [0003](0003-model-household-finance-with-parties.md) | Model people and financial entities as Parties | Proposed | - | - | - | - | Pryvance will use Party as the canonical actor in ownership, allocation, obligation, contribution,… |
| [0004](0004-preserve-source-records-and-derive-financial-events.md) | Preserve immutable Source Records and derive Financial Events | Proposed | - | - | - | - | Pryvance will store immutable Source Records for provider/import facts and derive normalized… |
| [0005](0005-use-deterministic-core-with-constrained-ai.md) | Keep financial truth deterministic and constrain AI to interpretation | Proposed | - | - | - | - | Pryvance will use deterministic application code for financial truth and expose AI only through… |
| [0006](0006-separate-visibility-from-ownership-and-coverage.md) | Separate visibility from ownership and data coverage | Proposed | - | - | - | - | Pryvance will model account/record ownership, visibility permissions, and source-data coverage as… |
<!-- adr-index:end -->
