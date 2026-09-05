# Pryvance delivery roadmap

Kind: explanation

This roadmap is a dependency-ordered engineering timeline, not a release promise. Hours are focused implementation/test/documentation time and should be recalibrated from actual velocity after each phase.

## Guiding rule

Build the financial truth layer before advanced analytics. A beautiful forecast over incomplete or weakly reconciled data is worse than a smaller, trustworthy ledger.

## Timeline summary

| Phase | Outcome | Estimated focused effort | Cumulative |
|---|---|---:|---:|
| 0 | Repository, architecture, deployment skeleton | 8–16 h | 8–16 h |
| 1 | Core household + account + transaction ledger | 30–50 h | 38–66 h |
| 2 | Imports, reconciliation, rules, review inbox | 25–40 h | 63–106 h |
| 3 | Budget + household funding + settlements | 30–45 h | 93–151 h |
| 4 | Provider sync + resilient history coverage | 25–40 h | 118–191 h |
| 5 | Receipts + line items + matching | 35–55 h | 153–246 h |
| 6 | Investments + known net worth | 30–50 h | 183–296 h |
| 7 | Documents + rental-property records | 40–65 h | 223–361 h |
| 8 | Local AI enrichment + evidence-linked analytics | 35–60 h | 258–421 h |
| 9 | Multi-user privacy hardening + advanced planning | 40–80 h | 298–501 h |

The earlier 40–60 hour “bank-fed budgeting MVP” estimate still maps roughly to the end of Phases 1–2 with a narrow budget slice. The broader product vision intentionally expands beyond that MVP.

## Phase 0 — foundation

Deliver:

- solution structure and modular boundaries;
- ASP.NET Core + React build/serve path;
- PostgreSQL + migrations;
- Docker Compose;
- test projects and baseline CI;
- structured logging with sensitive-data rules;
- documentation checks and ADR workflow.

Exit condition: one-command local startup, health check, database migration, and a thin vertical API/UI slice.

## Phase 1 — trusted ledger

Deliver:

- Household, Party, Person, Financial Entity;
- Accounts and ownership;
- visibility-policy primitives;
- immutable Source Records;
- normalized Financial Events;
- categories/subcategories;
- allocations;
- transaction list/detail UI;
- basic manual entry/editing of derived fields;
- source/provenance display.

Exit condition: manually imported or seeded account activity can be represented without conflating account ownership, category, beneficiary, or entity scope.

## Phase 2 — ingest and exception handling

Deliver:

- CSV import first, followed by OFX/QFX;
- deterministic fingerprints and idempotency;
- duplicate/conflict preview;
- pending/posting reconciliation model;
- transfer and credit-card-payment matching;
- rules engine;
- generalized Review Items and Review Inbox;
- source coverage/history reporting.

Exit condition: a large historical import can be repeated safely and the user only reviews uncertainty.

## Phase 3 — household operating model

Deliver:

- year-specific Budget model;
- annual targets with monthly defaults/overrides;
- YTD expected/actual/variance/annual remaining/safe monthly spend;
- Household Funding Plans;
- proportional/equal/custom contribution methods;
- obligations and settlements;
- contribution credits vs reimbursements;
- personal/shared scope reporting.

Exit condition: the joint-account funding scenario can be calculated, explained, and reconciled without treating transfers or settlements as spending/income.

## Phase 4 — live provider sync

Deliver:

- provider abstraction;
- first selected banking aggregator adapter;
- background incremental synchronization;
- provider account mapping;
- webhook/poll handling as supported;
- sync status, earliest-history date, and gaps;
- coexistence with historical imports.

Provider selection is intentionally deferred until implementation so current institution support, price, and data quality can be verified.

Exit condition: live provider data and historical files merge into one idempotent ledger with explicit coverage.

## Phase 5 — receipts

Deliver:

- desktop upload and mobile PWA capture;
- immutable receipt storage;
- deterministic receipt/transaction scoring;
- extraction pipeline;
- line items;
- category and Party allocation at line-item level;
- validation of subtotal/tax/tip/total reconciliation;
- Review flow for uncertain extraction or matching;
- optional email-receipt ingestion after upload flow is stable.

Exit condition: a photographed receipt can enrich a matched bank transaction and produce trustworthy splits.

## Phase 6 — investments and wealth

Deliver:

- investment-account types;
- holdings/valuation snapshots;
- contributions, employer contributions, buys/sells/dividends/fees/distributions;
- investment source coverage by fact family;
- retirement by Person and Household;
- Known Net Worth with partial-coverage labels;
- asset allocation and contribution analytics.

Exit condition: retirement and brokerage values coexist with cash flow without contributions/transfers becoming spending.

## Phase 7 — financial records and property

Deliver:

- immutable Document vault;
- document classification;
- versioned known-form schemas for selected forms;
- extracted facts with provenance;
- property/rental Financial Entity views;
- lease/mortgage/property-tax/insurance/invoice associations;
- rental income/expense/capital-improvement reporting;
- owner-funded property expenses.

Exit condition: a rental-property report drills to transactions and documents, and extracted financial facts drill to original evidence.

## Phase 8 — local intelligence

Deliver:

- OpenAI-compatible AI provider abstraction;
- LM Studio integration;
- structured-output extraction/classification;
- constrained analytics/query tools;
- AI-assisted merchant normalization and ambiguous categories;
- evidence-linked natural-language analysis;
- optional embeddings/semantic document search after structured extraction is mature.

Exit condition: AI can explain and navigate data without direct SQL access or authority over financial truth.

## Phase 9 — advanced household privacy and planning

Candidates after measured need:

- separate household logins;
- guardian permissions;
- balance-only/summary/shared-transaction permission UX;
- transaction-level private/gift controls;
- stronger encryption envelopes where required;
- tax workspace views;
- scenario/What If modeling;
- scheduled insights;
- native mobile only if PWA limitations become material.

## Recalibration points

At the end of Phases 2, 5, and 7, record actual hours and defect/rework rates. Re-estimate remaining phases rather than preserving the original ranges for appearance's sake.
