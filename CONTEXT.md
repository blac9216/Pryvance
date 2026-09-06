# CONTEXT.md — glossary

Canonical Pryvance vocabulary. The design set describes the feature-complete target architecture; the roadmap only sequences implementation.

## Household and identity

**Household** — single collaboration root represented by one Pryvance installation. Groups People, Financial Entities, shared planning, tax contexts and reporting. Not: SaaS tenant.

**User Identity** — authenticated application identity that may represent a Person. Not: Party.

**Household Membership** — link between User Identity and Household carrying application role/status. Not: financial ownership.

**Guardian Relationship** — authorized management relationship involving a guardian and child Person. Not: Account ownership.

## Parties, ownership, Assets and scope

**Party** — actor that can own, fund, receive, contribute or bear responsibility. Initial kinds: Person, Financial Entity. Not: Asset, login.

**Person** — human Party, including adult/child, with or without User Identity or connected Accounts.

**Financial Entity** — non-person Party such as LLC, trust or business. May own Accounts/Assets and be owned by Parties. Not: Property, Economic Scope.

**Party Ownership** — effective-dated economic ownership of a Financial Entity by a Party. Recursive chains allowed; cycles forbidden.

**Asset** — owned economic item such as real estate whose identity/value is separate from owner Party.

**Asset Ownership** — effective-dated Party ownership of an Asset. Not: Economic Scope allocation.

**Economic Scope** — canonical allocation/planning/reporting target representing Household, Person, Financial Entity or Asset. Not: ownership.

**Account** — financial account whose ownership, balances, activity, statements, Coverage and visibility are tracked independently.

**Account Ownership** — effective-dated Party→Account ownership relationship. Not: beneficiary/allocation.

**Liability** — canonical economic debt/obligation such as mortgage, loan, policy loan or security-deposit liability; may link to Account/Asset.

**Liability Party Relationship** — effective-dated relationship between Party and Liability with legal role/exposure and optional economic share used for planning/net-worth attribution. Not: Asset ownership.

## Ledger and source truth

**Source Record** — immutable observation received from provider, file, Document-derived/manual source or other ingestion channel before interpretation.

**Source Relationship** — immutable relationship between Source Records such as supersedes, pending-posted, correction-of, duplicate-of or related-source.

**Reconciliation Link** — association from Source Record evidence to Financial Event/Account Entry it supports.

**Financial Event** — normalized economic event such as expense, income, transfer, card payment, contribution, distribution, reimbursement, Settlement, refund, fee, interest or investment activity.

**Account Entry** — native-currency change in one Account participating in a Financial Event. Multiple entries may form linked transfer/payment/conversion.

**Financial Event Relationship** — semantic link between normalized events such as refund-of, reversal-of, chargeback-of, reimbursement-for, adjustment-to or fee-for.

**Allocation** — attribution of an economically allocatable Financial Event amount to Category and/or Economic Scope. Not: Account Entry.

**Money** — decimal amount plus native currency. Native amount is never overwritten by reporting conversion.

**Economic Amount / Allocation Basis** — Money basis against which event Allocations reconcile when the event is economically allocatable. May differ from Account settlement currency.

**FX Conversion** — actual/observed conversion relationship between native monetary amounts/entries. Not: market reference rate.

**FX Rate Observation** — sourced historical/current currency conversion rate for effective date/time. Not: actual bank settlement unless evidence says so.

**Reporting Currency** — configurable Household default/home currency used for derived views; reports may override it. Not: source currency.

**Account Balance Observation** — sourced balance for an Account at an as-of date/time with native currency and Provenance.

**Account Statement** — evidence-backed period statement for an Account, including statement-specific facts.

**Statement Obligation** — payment requirement derived from statement, such as card statement balance/minimum due.

**Statement Reconciliation** — comparison of statement opening balance + reconciled activity against statement closing balance, including unexplained difference/status.

**Merchant / Counterparty** — canonical external counterparty identity with aliases. Not: raw provider description.

**Category** — validated hierarchical classification for economic purpose. Not: Economic Scope.

**Rule** — deterministic, inspectable matching/normalization/classification logic. Not: AI prompt.

## Time and calculation history

**Financial Date** — source/business date used for financial-period attribution. Not: UTC knowledge timestamp.

**Knowledge Time** — instant when Pryvance learned, derived, verified or changed information.

**Calculation Run** — reproducibility record for a material derived result containing calculation version, knowledge cutoff, plan/policy versions, reporting currency, inputs/evidence manifest, Coverage, assumptions and outputs.

## Recurrence and planning

**Recurring Pattern** — accepted recurring financial behavior with cadence/amount expectations. Not: one-off event.

**Expected Cash Flow** — future expected occurrence produced by accepted recurrence or explicit schedule.

**Commitment** — known/estimated required cash use such as mortgage, premium, childcare, tax payment or card payoff.

**Reserve Bucket** — economic earmark of liquid cash for a purpose without requiring separate physical Account.

**Savings Goal** — target amount/date/priority for future objective such as 529, vacation, vehicle or major purchase.

**Budget Plan** — planned spending/saving targets for an Economic Scope. Not: Funding Plan.

**Budget Plan Version** — effective-dated Budget targets/defaults/overrides.

**Household Funding Plan** — Household rule set for shared Commitments, reserves, goals, buffer, eligible-income definition, contribution method and correction policy.

**Funding Plan Version** — effective-dated Funding Plan configuration.

**Contribution** — accepted value supplied toward Funding Plan, including configured direct-deposit/transfers and approved shared-spending credits.

**Funding Reconciliation** — target-vs-actual shared contribution comparison with cumulative fairness variance/correction policy. Not: interpersonal debt.

**Obligation** — explicit debtor/creditor responsibility when direct settlement semantics are deliberately chosen.

**Settlement** — Financial Event reducing/clearing explicit Obligation without creating new income/spending.

**Scenario** — isolated What If projection over observed state plus explicit assumptions; never mutates observed truth.

**Scenario Assumption** — explicit hypothetical input to Scenario.

**Free Cash** — liquid value projected to remain safely spendable after applicable Commitments, required contributions, protected reserves and configured goal funding for a stated horizon.

## Evidence, vault and storage

**Stored Object** — immutable original file bytes identified by SHA-256. Not: Document metadata row or user-controlled path.

**Object Replica** — recoverable representation of a Stored Object on a specific Storage Target, hot or cold, raw or archived, with integrity/state metadata.

**Storage Target** — configured location capable of storing object replicas/archive/backup artifacts, such as local volume, mounted HDD/NAS or cloud provider via External Connection.

**Archive Pack** — bounded, immutable, indexed collection of cold Stored Object payloads; may be compressed and locally encrypted depending on target trust.

**Archive Pack Entry** — indexed mapping from Stored Object original identity to its representation/location in Archive Pack.

**Rehydration** — durable process that retrieves/decrypts/decompresses archived object, verifies original SHA-256 and creates hot replica.

**Evidence** — source artifact/record supporting a fact, valuation, match, reconciliation, Coverage assertion or interpretation.

**Provenance** — metadata explaining why Pryvance believes a fact: source, parser/extractor/matcher/rule/model version, location, confidence and verification. Not: Audit.

**Audit Entry** — append-only record of who/what changed application state and when. Not: Provenance.

**Receipt** — immutable purchase evidence plus extracted merchant/payment/total facts.

**Receipt Item** — extracted/verified line item with independent Category/Economic Scope allocation capability.

**Document** — immutable financial source material such as U.S. tax form, statement, pay stub, lease, invoice, policy, illustration, appraisal or return.

**Extracted Fact** — structured semantic value derived from Evidence with Provenance/effective/knowledge/verification metadata.

**Verification** — user/system confirmation/correction state for derived fact while preserving source evidence.

**Payroll Record** — structured pay-period facts including gross, taxes, deductions, retirement contributions, benefits and net pay.

## Data quality and review

**Coverage** — known completeness of source data for resource/scope/date interval/fact family. Not: confidence.

**Review Item** — unresolved uncertainty requiring user judgment with evidence/candidate resolutions/owning module/history. Not: Alert.

## Investments and wealth

**Security / Instrument** — canonical investment instrument identity independent of provider symbol.

**Investment Transaction** — investment-specific activity linked to ledger such as buy, sell, contribution, dividend, fee, distribution, rollover or reinvestment.

**Position Snapshot** — sourced holdings/value observation for Security/Investment Account at as-of time.

**Price Observation** — sourced Security price/currency observation.

**Tax Lot** — tracked quantity/cost-basis lot when Coverage supports it; unknown basis is not zero.

**Valuation Observation** — sourced value estimate/measurement for Asset/economic item at effective date.

**Known Net Worth** — deduplicated net worth from tracked/permitted canonical items and ownership/responsibility paths, explicitly qualified when Coverage incomplete.

## Insurance

**Insurance Policy** — first-class coverage/financial policy record with owner, insured, beneficiaries, premiums, status, Documents and type-specific facts.

**Policy Value Observation** — dated observed cash value, surrender value, death benefit, loan balance or other policy value fact. Not: projection.

**Policy Illustration** — immutable projected policy-value evidence with assumptions and guaranteed/non-guaranteed series.

## Property and U.S. tax

**Real Estate Property** — Asset specialization for owned/rental property. Not: Financial Entity.

**Tax Year** — U.S. tax reporting year used to group filing contexts/evidence. Not: Budget year.

**Tax Filing Context** — year-specific Joint or Individual U.S. tax-preparation collaboration/authorization scope. Not: global Visibility override.

**Filing Access Grant** — explicit filing-context permission to use/view tax Documents/facts for preparation.

**Tax Classification Candidate** — potential U.S. tax treatment/category requiring verification. Not: final tax advice/decision.

## Privacy, search and integrations

**Visibility Policy** — rules for detail visibility, aggregate inclusion, Household calculation use, Tax Filing Context use and mutation permission. Not: ownership.

**External Connection** — configured provider link with authentication method, credential reference, granted scopes/capabilities, owner and health.

**External Capability** — provider function such as Bank Data, Mail Read, Mail Send, Cloud Storage, Market Data, FX Rates, AI Inference or Notification Delivery.

**Mail Ingestion Rule** — explicit mailbox/folder/query/source criteria controlling receipt/document ingestion. Not: general mail-client filter.

**AI Provider** — configured local/remote inference provider behind bounded/redacted Pryvance interface. Not: financial truth source.

## Jobs, Alerts and delivery

**Outbox Message** — transactionally committed instruction/event used to materialize required asynchronous Job after domain state commit.

**Job** — durable asynchronous work item with type, priority, schedule, retry/lease/concurrency state and resource references.

**Job Attempt** — one execution attempt of Job with worker/timing/sanitized result/retry metadata.

**Job Schedule** — persistent cadence definition that creates durable Jobs. Not: timer that directly executes domain work.

**Alert** — stable actionable/informational product condition such as cash risk, sync failure, missing tax Document or storage integrity issue. Not: delivery channel.

**Notification Delivery** — mechanism/attempt that delivers Alert/Insight in-app, push, email or future adapter.

**Scheduled Insight** — recurring authorized analytical definition that produces Insight/Alert via normal delivery rules.

## Backup and recovery

**Database Backup** — versioned authenticated/encrypted PostgreSQL logical recovery artifact plus schema/application/catalog metadata.

**Object Recovery Snapshot** — manifest proving the set of Stored Objects required by a database snapshot and the recovery-eligible replicas that satisfy each requirement.

**Recovery Point** — coherent logical recovery unit linking verified Database Backup and verified Object Recovery Snapshot. Not: necessarily one physical file.

**Backup Set** — logical recovery set represented by a Recovery Point; database/object streams may be physically separate. Not: monolithic zip requirement.

**Backup Envelope** — authenticated encrypted recovery artifact sent to untrusted/offsite storage. May contain database or other recovery artifact; not necessarily all objects.

**Backup Destination** — Storage Target eligible for disaster-recovery artifacts. A cold cloud Storage Target may also be a Backup Destination.

**Recovery Secret** — independently held secret material required to recover encrypted offsite Database Backups/archive/object recovery artifacts after host loss. Not: provider credential.
