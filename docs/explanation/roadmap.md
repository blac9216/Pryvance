# Pryvance delivery roadmap

Kind: explanation

This roadmap sequences implementation of the feature-complete target architecture described by the rest of the design set. A capability appearing in a later phase is already part of the intended architecture; the phase only says when it becomes operational.

The roadmap is dependency ordered, not a release promise. Hours are focused implementation, testing, migrations, documentation and hardening time. Estimates should be recalibrated from actual velocity after each major phase.

## Guiding rules

1. Build reliable financial truth before advanced interpretation.
2. Establish authentication, durable work, auditability and recoverability before onboarding irreplaceable real data.
3. Implement domain interfaces according to the target architecture even when only one provider/worker/target exists initially.
4. Do not use roadmap sequencing as justification for schema shortcuts that contradict target-state capabilities.
5. New data families define Coverage, Evidence/Provenance, authorization and recovery behavior before analytics depends on them.
6. A transport success is not proof of financial, object-storage or backup correctness; reconciliation/integrity/restore checks matter.

## Target architecture references

- [Architecture](architecture.md) — C4 views, target components, dynamic flows and invariants.
- [Domain model](domain-model.md) — feature-complete domain semantics.
- [Planning and forecasting](planning-and-forecasting.md) — budgets, shared funding, commitments, reserves, forecasts and scenarios.
- [Wealth, records and tax](wealth-records-and-tax.md) — Assets, investments, insurance, property, payroll and U.S. tax workspace.
- [Integrations and automation](integrations-and-automation.md) — External Connections, AI, search, Alerts and Scheduled Insights.
- [Storage lifecycle and recovery](storage-and-recovery.md) — content-addressed hot/cold vault, Archive Packs, rehydration and split recovery streams.
- [Background jobs](operations-and-jobs.md) — PostgreSQL queue/outbox, leases, retries, schedules and concurrency.
- [Security and privacy](security.md) — target authorization/privacy/trust model.
- [Target PostgreSQL data model](../reference/data-model.md) — persistence blueprint and ER diagrams.
- [API contract](../reference/api-contract.md) and [operational API](../reference/operations-api.md) — target REST surfaces.
- [Alert catalog](../reference/alert-catalog.md) — stable core product Alert types.

## Timeline summary

| Phase | Implementation outcome | Estimated focused effort | Cumulative |
|---|---|---:|---:|
| 0 | Repository, deployment, auth/audit, durable jobs + encrypted database/object recovery foundation | 40–60 h | 40–60 h |
| 1 | Household/identity/scope + multi-currency trusted/reconcilable ledger | 50–80 h | 90–140 h |
| 2 | Imports, reconciliation, rules, recurring detection + Review | 40–60 h | 130–200 h |
| 3 | Budget, shared funding fairness, commitments/reserves + cash/card forecast | 45–70 h | 175–270 h |
| 4 | External Connections, live bank sync, Alerts + notification plumbing | 40–60 h | 215–330 h |
| 5 | Tiered document vault, receipts, extracted facts + payroll intelligence | 65–100 h | 280–430 h |
| 6 | Investments, securities, valuation/FX + Known Net Worth | 50–80 h | 330–510 h |
| 7 | Assets, entity ownership, property + liability accounting | 45–70 h | 375–580 h |
| 8 | Insurance inventory + permanent-policy value/projection tracking | 25–40 h | 400–620 h |
| 9 | U.S. Tax Filing Contexts, tax workspace + accountant export | 35–55 h | 435–675 h |
| 10 | AI/search/anomaly enrichment + advanced scenarios | 45–75 h | 480–750 h |
| 11 | Multi-user privacy UX, Scheduled Insights + full product hardening | 35–60 h | 515–810 h |

The range is intentionally broad. The approved target is substantially beyond a budgeting MVP: it includes immutable Evidence/Provenance, purpose-aware privacy, planning/forecasting, reconciled statements, multi-currency, investments, recursive ownership, property/liabilities, insurance, U.S. tax evidence, tiered object storage, durable jobs, external integrations, AI/search and independently verified disaster recovery.

## Phase 0 — foundation, security, durable work and recoverability

Implement:

- solution/repository/module structure;
- ASP.NET Core + React build/serve path;
- PostgreSQL + migrations;
- Docker Compose/private-network topology;
- authentication/session boundary and initial User Identity/Household root;
- Audit Entry and structured sensitive-data-safe logging;
- target Money/date/time primitives;
- PostgreSQL-backed durable Job table, Job Attempt, priority/lease/retry/concurrency foundation;
- transactional Outbox Message pattern for state changes that require asynchronous follow-up;
- persistent Job Schedule foundation;
- application secret/configuration pattern;
- content-addressed Stored Object catalog and local hot Storage Target abstraction sufficient for later vault work;
- Storage Target interface supporting mounted filesystem/NAS/HDD and External Connection-backed cloud targets;
- Database Backup artifact/version model;
- Recovery Secret generation/export/verification using a vetted encryption/key-wrapping implementation;
- Object Recovery Snapshot/Recovery Point manifest model;
- first encrypted offsite target, with Google Drive an intended initial choice unless implementation constraints favor an equivalent provider;
- backup/object-protection verification status;
- clean-environment database + required-object restore test;
- baseline CI/tests/docs checks.

Exit condition: one-command local startup, authentication, auditable state change, durable Job execution across restart, and a verified Recovery Point restorable into a clean Pryvance environment using the encrypted Database Backup, protected required objects and separately held Recovery Secret.

Real Household financial data should not be considered safely onboarded before this exit condition is demonstrated.

## Phase 1 — identity, scopes and trusted/reconcilable ledger

Implement the primitives every later feature depends on:

- Person and Financial Entity Parties;
- Household Membership/roles foundation;
- Economic Scope;
- effective-dated Account Ownership;
- Asset/Party and Liability Party relationship interfaces needed by later phases;
- visibility-policy primitives and purpose-aware authorization;
- native Money and configurable Household reporting currency;
- FX Conversion/FX Rate Observation foundations;
- financial/business date, provider instant/source timezone and knowledge-time semantics;
- immutable Source Records/Source Relationships;
- Financial Events and one-or-more Account Entries;
- Economic Amount/allocation-basis semantics for cross-currency events;
- Reconciliation Links;
- Financial Event Relationships for refund/reversal/chargeback/reimbursement/adjustment/fee semantics;
- category hierarchy and Merchant/Counterparty foundation;
- category/Economic Scope Allocations;
- Account Balance Observations;
- Account Statement/Statement Reconciliation foundations;
- manual observations/Provenance;
- basic Coverage;
- transaction list/detail/source drill-down;
- Calculation Run foundation for material reproducible analytics.

Exit condition: seeded/imported activity can be represented without conflating Account ownership, Economic Scope, category, visibility or evidence; transfers/card payments/cross-currency activity preserve native truth; a statement period can expose whether its ledger balances reconcile; all state participates in Audit and Recovery Point protection.

## Phase 2 — ingest, deterministic reconciliation and exception handling

Implement:

- CSV import, then OFX/QFX;
- deterministic fingerprinting/idempotency;
- import preview/overlap/conflicts;
- Source Relationships for duplicate/correction/pending-posted data;
- transfer and credit-card-payment matching;
- refund/reversal/reimbursement semantic linking;
- statement/balance reconciliation workflow and unexplained-difference Review/Alerts;
- rules engine and historical rule testing;
- generalized Review Items/Review Inbox;
- Merchant alias/canonicalization workflow;
- Recurring Pattern detection/candidate flow;
- Expected Cash Flow primitives;
- Coverage/history-gap reporting;
- stable ledger/data Alert types from the Alert catalog.

Exit condition: large historical imports can repeat safely, overlapping sources reconcile without deleting evidence, statements can prove/flag period completeness, and users spend attention on true uncertainty rather than routine deterministic work.

## Phase 3 — Household operating model and forecasting

Implement:

- Budget Plan roots/versions;
- annual targets, monthly defaults/overrides;
- YTD pace/annual remaining/safe monthly spend;
- Household Funding Plan roots/versions;
- eligible-income definitions;
- contribution methods/targets;
- Funding Reconciliation/cumulative variance;
- correction policies including future-percentage carry-forward;
- Commitments;
- Reserve Buckets;
- Savings Goals;
- actual contribution recognition from shared Account activity;
- optional explicit Obligation/Settlement path;
- deterministic short-range cash forecast;
- `actually free cash`;
- credit-card statement/full-payoff/minimum-payment risk;
- material forecast/funding Calculation Runs and stable planning Alerts.

Exit condition: the Household can fund shared needs fairly without routing all income through a joint Account, carry historical fairness corrections forward, and forecast whether liquid cash can cover near-term Commitments/card statements.

## Phase 4 — External Connections, live data and Alerts

Implement:

- External Connection/authentication-method/capability model;
- encrypted provider credential storage;
- first live bank aggregator adapter;
- incremental sync/webhook/polling through durable Jobs;
- provider Account mapping;
- sync Coverage/gap status;
- coexistence with file history;
- generic Alert persistence/dedup/resolution/snooze semantics;
- in-app Alert inbox;
- notification preferences/destination abstraction;
- initial PWA/Web Push and/or email delivery path;
- connection/sync/job/storage/recovery health Alerts;
- operational Job/schedule APIs and UI visibility appropriate for self-host administration.

Provider choice remains implementation-time because institution support, price and data quality change; the target provider-neutral contract remains fixed.

Exit condition: live bank data merges with historical imports into one idempotent ledger, asynchronous failures survive restart and are inspectable, and Alerts remain domain facts independent of delivery mechanism.

## Phase 5 — tiered vault, receipts, Documents and payroll

Implement:

- full Stored Object/Object Replica lifecycle;
- configurable hot/cold Storage Policy;
- bounded immutable indexed Archive Packs;
- mounted HDD/NAS cold target support;
- encrypted cloud cold target support through External Connection;
- policy allowing cloud cold replica to also satisfy object disaster-recovery requirements;
- archive/verification/compaction Jobs;
- user-requested high-priority Rehydration with SHA-256 validation;
- optional small rebuildable hot previews/thumbnails;
- retention settings/default indefinite original retention;
- desktop upload/mobile PWA receipt capture;
- deterministic receipt-to-event scoring;
- receipt extraction/validation and Receipt Items;
- Document vault/classification;
- Extracted Fact/Verification/Provenance model;
- selected versioned known-form schemas;
- Mail Ingestion Rules through External Connection;
- payroll/pay-stub extraction;
- payroll net-pay-to-bank reconciliation;
- employee/employer retirement contribution facts;
- authorized structured-metadata search foundation;
- object/storage/vault Alerts;
- restore tests proving cold archives can reconnect and objects can rehydrate after database recovery.

Exit condition: recent originals are immediately viewable, old evidence can leave primary SSD and rehydrate on demand, no object loses canonical identity or recovery protection during tiering, and payroll/documents enrich the ledger without overwriting source evidence.

## Phase 6 — investments, FX and Known Net Worth

Implement:

- investment Account types;
- Security/Instrument master and provider mappings;
- investment transactions;
- Position Snapshots;
- Price Observations/market-data adapter;
- Tax Lot/cost-basis model and Coverage;
- contribution/employer-contribution reporting;
- performance methods with data-sufficiency guards/Calculation Runs;
- production FX provider adapter(s), historical-rate fetch and current-balance revaluation Jobs;
- reporting-currency override and stale/missing FX Coverage;
- ownership/responsibility-path net-worth engine;
- canonical-item deduplication;
- Known Net Worth/coverage labels;
- retirement/beneficiary views including 529/custodial semantics.

Exit condition: cash, investments, foreign-currency balances and indirect ownership can be valued without double counting; return metrics refuse unsupported precision; conversion basis/rate provenance is visible.

## Phase 7 — Assets, Financial Entities, property and liabilities

Implement:

- full recursive Party→FinancialEntity ownership with cycle prevention;
- Asset/effective Asset Ownership;
- Valuation Observations;
- generic Liability and Liability Party Relationships including economic share/legal role;
- Real Estate Property specialization;
- mortgage statement/fact model;
- principal/interest/escrow reconciliation;
- leases;
- security-deposit liabilities;
- rental income/operating expense projections;
- owner-funded property costs;
- repair/capital-treatment candidate workflow;
- Property Documents/Evidence associations.

Exit condition: a Person's Known Net Worth can traverse an LLC to its property/accounts/liabilities exactly once; jointly or differently attributed debt is modeled independently from Asset ownership; rental reports drill to shared ledger/evidence.

## Phase 8 — insurance

Implement:

- general Insurance Policy inventory;
- owner/insured/beneficiary relationships;
- premiums/coverage/status/Documents;
- recurring insurance-payment discovery suggestions;
- permanent-life cash/cash-surrender/death-benefit observations;
- policy loans and Liability relationships;
- dividends/paid-up-additions where supported;
- Policy Illustrations with guaranteed/non-guaranteed series;
- actual-vs-illustration comparisons;
- appropriate Known Net Worth inclusion rules and insurance Alerts.

Exit condition: whole/permanent-life policies are evidence-backed financial/coverage records, policy loans are visible and historical projections can be compared with observed values without treating death benefit/projections as current assets.

## Phase 9 — U.S. tax workspace and filing contexts

Implement:

- Tax Year/Tax Filing Context (`Joint`/`Individual`);
- filing-specific access grants;
- tax-document checklist/missing-document Alerts;
- selected W-2/1099/1098-style extraction/refinement;
- filing-context document/evidence search;
- rental Schedule-E-style organization;
- payroll/tax-document reconciliation;
- itemization/supporting-receipt discovery including rehydration of cold evidence when requested;
- tax classification candidates requiring verification;
- accountant/tax-preparer ZIP/package export;
- audited export manifests;
- tax-context AI companion hooks.

Exit condition: joint filing intentionally exposes only tax materials required for preparation, individual filing can still permit selected private facts for Household fairness calculations, and users can export a coherent evidence package for an accountant/preparation tool.

Non-U.S. tax-return architecture remains outside the approved target; multi-currency financial evidence remains supported independently.

## Phase 10 — AI, semantic search, anomaly intelligence and advanced scenarios

Implement:

- provider-neutral AI configuration/API;
- LM Studio/OpenAI-compatible local adapter;
- configurable remote-provider path;
- authorization/redaction/minimization gateway with stable placeholders;
- structured extraction/classification contracts;
- constrained typed AI tools;
- evidence-linked natural-language answers;
- semantic search/embeddings over authorized data;
- richer recurring/anomaly analysis;
- forgotten-subscription/expected-income anomalies;
- advanced Scenario engine/What If projections;
- as-known-now vs as-known-then comparisons using Calculation Runs;
- AI/anomaly Jobs with provider/resource concurrency limits.

Exit condition: AI/search interprets/navigates data without unrestricted SQL or authority over financial truth, private records do not leak through retrieval/indexing, and scenarios remain isolated from observed state.

## Phase 11 — multi-user privacy UX, Scheduled Insights and hardening

Implement/harden:

- separate Household user-login UX;
- Manager/Viewer/Guardian workflows;
- balance-only/summary/shared-transaction permission UX;
- record/document/fact overrides including gifts/private-until-date;
- Tax Filing Context permission UX refinement;
- privacy propagation tests across search, Review, analytics, AI, Alerts, notifications and exports;
- Scheduled Insights using durable Job Schedules;
- user/channel-specific notification tuning;
- operational dashboards for Jobs, External Connections, Storage Targets, archive/recovery health and Alerts;
- retention/deletion UX with Recovery Point disclosure;
- performance/indexing/worker-container separation only where measured need justifies it;
- native mobile only if PWA constraints become material.

Exit condition: the complete designed privacy model is usable by multiple Household members without administrator knowledge, recurring insights/Alerts are tunable, vault/recovery operations are understandable, and cross-surface privacy/recovery/data-quality tests pass.

## Continuous concerns across phases

### Recovery

Every phase adds newly introduced database state and Stored Objects to coherent Recovery Point testing. Database Backup success is not sufficient if required objects are unprotected. Object archival and database backup may use separate physical streams/targets.

### Jobs and idempotency

Background work introduced in any phase uses the durable Job/outbox/schedule model. Handlers are idempotent and declare concurrency/retry semantics rather than adding ad-hoc timers or process-local queues.

### Audit, Provenance and Calculation Runs

Every financially/security-material mutation or derived fact uses the target Audit/Provenance model. Material historical recommendations/results retain sufficient Calculation Run metadata when reproducibility matters.

### Authorization

Features may initially have one active user, but queries/endpoints are written against purpose-aware authorization interfaces rather than global visibility assumptions.

### Coverage/reconciliation

New data families define Coverage before analytics relies on them. Where an independent balance/statement/source can prove completeness, reconciliation state is exposed rather than inferred from row count.

### Storage lifecycle

New immutable evidence types use Stored Object identity and configured replica/recovery policy. Search indexes, thumbnails and other rebuildable derived data are kept separate from canonical originals.

### Documentation

Implementation that changes a durable design decision updates the relevant ADR/design set. Roadmap changes sequence, not architectural truth.

## Recalibration points

At the end of Phases 2, 5, 7 and 9, record actual focused hours, defect/rework rates, storage growth, queue/job behavior and major architecture surprises. Re-estimate remaining phases using observed velocity rather than preserving the initial range for appearance's sake.
