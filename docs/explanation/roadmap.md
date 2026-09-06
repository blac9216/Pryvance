# Pryvance delivery roadmap

Kind: explanation

This roadmap sequences implementation of the feature-complete target architecture described by the rest of the design set. A capability appearing in a later phase is already part of the intended architecture; the phase only says when it becomes operational.

The roadmap is dependency ordered, not a release promise. Hours are focused implementation, test, migration, documentation, and hardening time and should be recalibrated from actual velocity after each major phase.

## Guiding rules

1. Build reliable financial truth before advanced interpretation.
2. Establish authentication, auditability, and recoverability before onboarding irreplaceable real data.
3. Implement domain interfaces according to the target architecture even when only one implementation/provider exists initially.
4. Do not use roadmap sequencing as justification for schema shortcuts that contradict later target-state capabilities.
5. Add advanced analytics only when Coverage and evidence quality can support them.

## Target architecture references

- [Architecture](architecture.md) — C4 views, target components, dynamic flows and cross-cutting invariants.
- [Domain model](domain-model.md) — feature-complete domain entities/relationships/invariants.
- [Planning and forecasting](planning-and-forecasting.md) — budgets, shared funding, fairness, commitments, reserves, forecasting and scenarios.
- [Wealth, records and tax](wealth-records-and-tax.md) — assets, investments, insurance, property, payroll and tax workspace.
- [Integrations and automation](integrations-and-automation.md) — External Connections, AI, search, alerts, notifications and jobs.
- [Security and privacy](security.md) — final authorization/privacy/trust model.
- [API contract](../reference/api-contract.md) — target application REST surface.

## Timeline summary

| Phase | Implementation outcome | Estimated focused effort | Cumulative |
|---|---|---:|---:|
| 0 | Repository, deployment, auth/audit baseline + encrypted recovery | 30–45 h | 30–45 h |
| 1 | Household/identity/scope + multi-currency trusted ledger | 45–70 h | 75–115 h |
| 2 | Imports, reconciliation, rules, recurring detection + Review | 35–55 h | 110–170 h |
| 3 | Budget, shared funding fairness, commitments/reserves + cash forecast | 45–70 h | 155–240 h |
| 4 | External Connections, live bank sync, alerts + notification plumbing | 35–55 h | 190–295 h |
| 5 | Receipts, Documents, extracted facts + payroll intelligence | 50–80 h | 240–375 h |
| 6 | Investments, securities, valuations, FX + Known Net Worth | 45–70 h | 285–445 h |
| 7 | Assets, entity ownership, property + liability accounting | 45–70 h | 330–515 h |
| 8 | Insurance inventory + permanent-policy value/projection tracking | 25–40 h | 355–555 h |
| 9 | Tax Filing Contexts, tax workspace + accountant export | 35–55 h | 390–610 h |
| 10 | AI/search/anomaly enrichment + advanced scenarios | 45–75 h | 435–685 h |
| 11 | Multi-user privacy UX, scheduled insights + full product hardening | 35–60 h | 470–745 h |

These ranges are intentionally wider than the early budgeting-MVP estimates because the approved feature-complete vision now includes deep evidence/provenance, privacy-aware multi-user operation, planning/forecasting, investments, assets/property, insurance, tax records, external integrations, AI/search, and disaster recovery.

## Phase 0 — foundation, security and recoverability

Implement:

- solution/repository structure and modular boundaries;
- ASP.NET Core + React build/serve path;
- PostgreSQL + migrations;
- Docker Compose/private storage layout;
- authentication/session boundary for real data;
- initial User Identity/Household root;
- Audit Entry infrastructure;
- structured logging with sensitive-data rules;
- baseline CI/tests/docs checks;
- application secret/configuration pattern;
- Backup Set manifest/version model;
- authenticated local encryption/decryption using a vetted implementation;
- Recovery Secret generation/export/verification;
- generic Backup Destination interface;
- first offsite adapter, with Google Drive an intended initial target unless implementation-time constraints favor an equivalent provider;
- scheduled backup/retention health;
- clean-environment restore validation.

Exit condition: one-command local startup, authentication, health/migration checks, thin authorized API/UI slice, auditable state change, and a complete encrypted backup restorable into a clean Pryvance environment using only the Backup Envelope plus separately held Recovery Secret.

Real Household financial data should not be considered safely onboarded before this exit condition is demonstrated.

## Phase 1 — identity, scopes and trusted ledger

Implement the target primitives required by every later feature:

- Person and Financial Entity Parties;
- Household Membership/roles foundation;
- Economic Scope;
- Account and effective-dated Account Ownership;
- Asset/Party ownership interfaces sufficient for future expansion;
- visibility-policy primitives and purpose-aware authorization;
- Money/currency model and initial FX observation support;
- immutable Source Records/Source Relationships;
- Financial Events and Account Entries;
- Reconciliation Links;
- category hierarchy;
- Merchant/Counterparty normalization foundation;
- Allocations by category/Economic Scope;
- manual observations/provenance;
- basic Coverage;
- transaction list/detail and source drill-down.

Exit condition: manually seeded/imported activity can be represented without conflating Account ownership, Economic Scope, category, visibility, or source evidence; transfers/card payments can use linked entries; native currencies are preserved; all state is backed up/audited.

## Phase 2 — ingest, reconciliation and exception handling

Implement:

- CSV import first, then OFX/QFX;
- deterministic fingerprinting/idempotency;
- import preview/overlap/conflict handling;
- Source Relationships for duplicate/correction/pending-posted state;
- transfer and credit-card-payment matching;
- rules engine and historical rule test;
- generalized Review Items/Review Inbox;
- merchant alias/canonicalization workflow;
- recurring-pattern detection/candidate flow;
- expected-cash-flow primitives;
- Coverage/history-gap reporting.

Exit condition: large historical imports can be repeated safely, overlapping sources reconcile without deleting evidence, and users focus on true uncertainty rather than routine deterministic work.

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
- credit-card statement/payoff-risk foundation.

Exit condition: the Household can fund shared expenses/savings fairly without routing all income through the joint Account, reconcile historical fairness, carry corrections forward, and forecast whether liquid cash can cover near-term commitments/card statements.

## Phase 4 — External Connections, live data and alerts

Implement:

- External Connection/authentication-method/capability model;
- encrypted provider credential storage;
- first live banking aggregator adapter;
- incremental sync/webhook/polling path;
- provider Account mapping;
- sync Coverage/gap status;
- coexistence with file history;
- generic Alert model;
- in-app alert inbox;
- notification preferences/destination abstraction;
- initial PWA/Web Push and/or email delivery path as practical;
- connection-health and backup/sync alerts.

Provider selection remains implementation-time because institution support, price and data quality change. The target provider-neutral contract remains fixed.

Exit condition: live bank data merges with historical imports into one idempotent ledger; failed connections/syncs are visible; alerts are domain objects independent of delivery mechanism.

## Phase 5 — receipts, records and payroll

Implement:

- immutable content-addressed Stored Objects;
- desktop upload/mobile PWA receipt capture;
- deterministic receipt-to-event scoring;
- receipt extraction/validation;
- Receipt Items and category/Economic Scope allocation;
- Document vault/classification;
- Extracted Fact/Verification/Provenance model;
- selected versioned known-form schemas;
- mail receipt/document ingestion through External Connection capability after upload flow is stable;
- payroll/pay-stub extraction;
- payroll net-pay-to-bank reconciliation;
- employee/employer retirement contribution facts;
- evidence retention settings/default indefinite retention;
- search foundation over authorized structured metadata.

Exit condition: receipts and documents enrich the ledger without overwriting source evidence, payroll connects income/tax/retirement/cash-deposit facts, and all new immutable objects restore cleanly from offsite backup.

## Phase 6 — investments, FX and net worth

Implement:

- investment Account types;
- Security/Instrument master and provider mappings;
- investment transactions;
- Position Snapshots;
- Price Observations/market-data adapter;
- Tax Lot/cost-basis model and Coverage;
- contribution/employer-contribution reporting;
- performance methods with data-sufficiency guards;
- richer FX rate observations/conversion reporting;
- ownership-path net-worth engine;
- canonical-item deduplication;
- Known Net Worth/coverage labels;
- retirement/beneficiary account views including 529/custodial semantics.

Exit condition: cash, investments and indirect ownership can be valued without double counting; return metrics refuse unsupported precision; foreign-currency holdings convert with visible sourced rates.

## Phase 7 — assets, entities, property and liabilities

Implement:

- full recursive Party→FinancialEntity ownership with cycle prevention;
- Asset and effective-dated Asset Ownership;
- Valuation Observations;
- generic Liability;
- Real Estate Property specialization;
- mortgage statement/fact model;
- principal/interest/escrow reconciliation;
- leases;
- security-deposit liabilities;
- rental income/operating expense projections;
- owner-funded property costs;
- repair/capital-treatment candidate workflow;
- property Documents/Evidence associations.

Exit condition: a Person's net worth can traverse an LLC to its property/accounts/liabilities exactly once; rental reports use the shared ledger and drill to evidence; deposits/mortgage components have correct economic semantics.

## Phase 8 — insurance

Implement:

- general Insurance Policy inventory;
- owner/insured/beneficiary relationships;
- premiums/coverage/status/Documents;
- recurring insurance-payment discovery suggestions;
- permanent-life cash/cash-surrender/death-benefit observations;
- policy loans;
- dividends/paid-up-additions fields where supported;
- Policy Illustrations with guaranteed/non-guaranteed series;
- actual-vs-illustration comparisons;
- appropriate net-worth inclusion rules.

Exit condition: whole-life/permanent policies can be tracked as evidence-backed financial assets/coverage, policy loans are visible, and historical projections can be compared with actual observations.

## Phase 9 — tax workspace and filing contexts

Implement:

- Tax Year/Tax Filing Context (`Joint`/`Individual`);
- filing-specific access grants;
- tax-document checklist/missing-document Alerts;
- selected W-2/1099/1098-style extraction/refinement;
- filing-context document/evidence search;
- rental Schedule-E-style organization;
- payroll/tax-document reconciliation;
- itemization/supporting-receipt discovery;
- tax classification candidates requiring verification;
- accountant/tax-preparer ZIP/package export;
- audited export manifests;
- tax-context AI companion hooks.

Exit condition: joint filing can intentionally expose the tax documents required for preparation without globally sharing unrelated finances; individual filing can still permit selected private facts for funding-fairness calculations; users can export a coherent evidence package for an accountant/preparation tool.

## Phase 10 — AI, semantic search, anomaly intelligence and advanced scenarios

Implement:

- provider-neutral AI interface;
- LM Studio/OpenAI-compatible local adapter;
- configurable remote-provider adapter path;
- authorization/redaction/minimization gateway and stable placeholders;
- structured extraction/classification contracts;
- constrained typed AI tools;
- evidence-linked natural-language answers;
- semantic search/embeddings over authorized data;
- richer recurring/anomaly analysis;
- forgotten subscription/expected-income anomalies;
- advanced Scenario engine/What If projections;
- as-known-now vs as-known-then analytical comparison where supported.

Exit condition: AI/search can interpret/navigate data without raw SQL or authority over financial truth, private records do not leak through retrieval/indexing, and long-range scenarios remain isolated from observed state.

## Phase 11 — full multi-user privacy UX, scheduled insights and hardening

Implement/harden:

- separate Household user login UX;
- Manager/Viewer/Guardian workflows;
- balance-only/summary/shared-transaction permission UX;
- transaction/document/fact overrides including gifts/private-until-date;
- Tax Filing Context permission UX refinement;
- privacy propagation tests across search, Review, analytics, AI, notifications and exports;
- Scheduled Insights;
- user/channel-specific notification tuning;
- operational dashboards/job health;
- retention/deletion UX and backup-retention disclosure;
- performance/indexing/worker separation only where measured need justifies it;
- native mobile only if PWA constraints become material.

Exit condition: the complete designed privacy model is usable by multiple Household members without relying on administrator knowledge, recurring insights/alerts are tunable, and cross-surface privacy/restore/data-quality tests pass.

## Continuous concerns across phases

### Backup and restore

Every phase must add newly introduced state/objects to the tested Backup Set. Backup/restore is never considered a Phase-0-only task.

### Audit and provenance

Every financially/security-material mutation or derived fact introduced in a phase must use the target Audit/Provenance model rather than adding ad-hoc logs/history later.

### Authorization

Features may initially have one active user, but new queries/endpoints must be written against the target purpose-aware authorization interfaces rather than global visibility assumptions.

### Coverage

New data families introduce Coverage semantics before analytics depends on them.

### Documentation

Implementation that changes a durable design decision updates the appropriate ADR/design set. Roadmap changes sequence, not architectural truth.

## Recalibration points

At the end of Phases 2, 5, 7 and 9, record actual focused hours, defect/rework rates and major architecture surprises. Re-estimate remaining phases using observed velocity rather than preserving the original ranges for appearance's sake.
