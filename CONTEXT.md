# CONTEXT.md — glossary

The canonical vocabulary of Pryvance. One entry per domain term; implementation details belong in the design set. The design documents describe the feature-complete target architecture; the roadmap only sequences implementation.

## Household and identity

**Household** — the single collaboration root represented by one Pryvance installation. Groups people, financial entities, shared planning, filing contexts, and reporting. Not: SaaS tenant, account.

**User Identity** — an authenticated application identity that may represent a Person. Not: Party, Person.

**Household Membership** — link between a User Identity and the Household carrying application role/status. Not: financial ownership.

**Guardian Relationship** — authorized management relationship between a guardian and child Person. Not: Account ownership.

## Parties, ownership and scopes

**Party** — an actor that can own, fund, receive, contribute, or bear responsibility. Initial kinds are Person and Financial Entity. Not: Asset, user login.

**Person** — a human Party, including adults and children, whether or not that person has connected Accounts or a User Identity. Not: user.

**Financial Entity** — a non-person Party such as LLC, trust, or business. May own Accounts/Assets and may itself be owned by other Parties. Not: property, category, Economic Scope.

**Party Ownership** — effective-dated percentage ownership of a Financial Entity by a Party. Ownership chains may be recursive but cannot contain cycles. Not: Account ownership.

**Asset** — an economically valuable object such as real estate whose ownership/value is tracked separately from the Party that owns it. Not: Financial Entity.

**Asset Ownership** — effective-dated percentage ownership of an Asset by a Party. Not: Economic Scope allocation.

**Economic Scope** — canonical target for allocation, planning, and reporting; may represent Household, Person, Financial Entity, or Asset. Not: Account ownership.

**Account** — a financial account whose ownership, visibility, Coverage, statements, and activity are tracked independently. Not: Economic Scope, wallet.

**Account Ownership** — effective-dated ownership relationship between Party and Account. Not: beneficiary/allocation.

## Ledger and source truth

**Source Record** — immutable observation as received from provider, file, document-derived input, manual observation, or other source before application interpretation. Not: Financial Event.

**Source Relationship** — immutable relationship between Source Records such as supersedes, pending-posted, correction-of, duplicate-of, or related-source. Not: user edit.

**Reconciliation Link** — association from Source Record evidence to the Financial Event/Account Entry it supports. Not: duplicate detection result alone.

**Financial Event** — normalized economic event such as expense, income, transfer, card payment, contribution, distribution, reimbursement, settlement, refund, fee, interest, or investment activity. Not: raw bank row.

**Account Entry** — change in one Account that participates in a Financial Event. Multiple entries may form a linked transfer/payment. Not: category allocation.

**Allocation** — attribution of a Financial Event amount to category and/or Economic Scope. Not: Account Entry, ownership.

**Money** — amount plus native currency. Native amount is never overwritten by reporting conversion. Not: bare decimal.

**FX Rate Observation** — sourced/provenance-bearing currency conversion rate for an effective time/date. Not: rewritten native amount.

**Merchant / Counterparty** — canonical external counterparty identity with aliases. Not: raw provider description.

**Category** — validated hierarchical classification for what economic value was for. Not: Economic Scope.

**Rule** — deterministic, inspectable matching/normalization/classification logic. Not: AI prompt.

## Recurrence and planning

**Recurring Pattern** — accepted recurring financial behavior with cadence/amount expectations derived from explicit or reviewed observations. Not: one-off transaction.

**Expected Cash Flow** — future expected occurrence produced by accepted recurrence or explicit schedule. Not: observed Financial Event.

**Commitment** — known/estimated required cash use such as mortgage, premium, childcare, tax payment, or card statement payoff. Not: Reserve Bucket.

**Reserve Bucket** — economic earmark of liquid cash for a purpose without requiring a separate physical Account. Not: bank account.

**Savings Goal** — target amount/date/priority for a future objective such as 529, vacation, vehicle, or major purchase. Not: Reserve Bucket.

**Budget Plan** — planned spending/saving targets for an Economic Scope. Not: Household Funding Plan.

**Budget Plan Version** — effective-dated version of Budget targets/defaults/overrides. Not: overwritten annual row.

**Household Funding Plan** — Household rule set for shared Commitments, reserves, goals, buffer, contribution method, eligible-income definition, and correction policy. Not: Budget.

**Funding Plan Version** — effective-dated configuration of a Household Funding Plan. Not: current percentage only.

**Contribution** — accepted value supplied toward a Household Funding Plan, including configured cash/direct-deposit contributions and approved shared-spending credits. Not: every transfer.

**Funding Reconciliation** — comparison of target versus actual accepted shared contributions over time, including cumulative fairness variance and correction policy. Not: interpersonal debt.

**Obligation** — explicit debtor/creditor responsibility when direct settlement semantics are intentionally used. Not: ordinary partner funding variance.

**Settlement** — Financial Event that reduces/clears an explicit Obligation without creating new income or spending. Not: contribution fairness adjustment.

**Scenario** — isolated What If projection over observed state plus explicit assumptions. Never mutates observed financial truth. Not: Budget Plan version.

**Scenario Assumption** — explicit hypothetical input to a Scenario. Not: Source Record.

**Free Cash** — liquid value projected to remain safely spendable after applicable Commitments, required contributions, protected reserves, and configured goal funding for a stated horizon. Not: Account balance.

## Statements and liabilities

**Account Statement** — evidence-backed period statement for an Account, including statement-specific facts such as card balance/due date. Not: Financial Event.

**Statement Obligation** — required payment derived from a statement, such as credit-card statement balance/minimum due. Not: purchase transaction.

**Liability** — canonical economic debt/obligation such as mortgage, loan, policy loan, or security-deposit liability; may link to Account/Asset. Not: Funding Reconciliation.

## Evidence and records

**Stored Object** — immutable content-addressed original file in private storage. Not: user-controlled filesystem path.

**Evidence** — source artifact/record supporting a financial fact, match, valuation, extraction, Coverage assertion, or interpretation. Not: attachment label.

**Provenance** — metadata explaining why Pryvance believes a fact: source, parser/extractor/matcher/rule/model version, location, confidence, and verification. Not: Audit Entry.

**Audit Entry** — append-only record of who/what changed application state and when. Not: Provenance.

**Receipt** — immutable purchase evidence plus extracted merchant/payment/total facts. Not: Financial Event.

**Receipt Item** — extracted/verified line item that may carry independent category and Economic Scope allocation. Not: transaction split only.

**Document** — immutable financial source material such as tax form, statement, pay stub, lease, invoice, policy, illustration, appraisal, or return. Not: Extracted Fact.

**Extracted Fact** — structured semantic value derived from Evidence with Provenance/effective/knowledge/verification metadata. Not: source document itself.

**Verification** — user/system confirmation/correction state for a derived fact while preserving original evidence. Not: source mutation.

**Payroll Record** — structured pay-period facts from pay stub/payroll evidence, including gross, taxes, deductions, retirement contributions, benefits, and net pay. Not: bank deposit.

## Data quality and review

**Coverage** — known completeness of source data for a resource, scope, date interval, or fact family. Not: confidence.

**Review Item** — unresolved uncertainty requiring user judgment, with evidence, candidate resolutions, owning module, and resolution history. Not: Alert.

## Investments and wealth

**Security / Instrument** — canonical investment instrument identity independent of provider symbol. Not: holding.

**Investment Transaction** — investment-specific activity such as buy, sell, contribution, dividend, fee, distribution, rollover, or reinvestment linked to the ledger. Not: Household spending by default.

**Position Snapshot** — sourced holdings/value observation for a Security/Investment Account at an as-of time. Not: transaction history.

**Price Observation** — sourced Security price/currency observation. Not: manually rewritten position value.

**Tax Lot** — tracked quantity/cost-basis lot when source Coverage supports it. Not: assumed zero basis.

**Valuation Observation** — sourced value estimate/measurement for an Asset or other economic item at an effective date. Not: timeless current value.

**Known Net Worth** — deduplicated net worth calculated only from tracked, permitted economic items and ownership paths, explicitly qualified when Coverage is incomplete. Not: guaranteed total Household net worth.

## Insurance

**Insurance Policy** — first-class coverage/financial policy record with owner, insured, beneficiaries, premiums, status, Documents, and type-specific facts. Not: recurring premium transaction.

**Policy Value Observation** — dated observed cash value, cash surrender value, death benefit, loan balance, or other policy value fact. Not: projection.

**Policy Illustration** — immutable projected policy-value evidence with assumptions and guaranteed/non-guaranteed series. Not: observed net-worth value.

## Property and tax

**Real Estate Property** — Asset specialization for owned/rental property. Not: Financial Entity.

**Tax Year** — tax reporting year used to group filing contexts/evidence. Not: Budget year.

**Tax Filing Context** — year-specific Joint or Individual tax-preparation collaboration/authorization scope. Not: global Visibility Policy override.

**Filing Access Grant** — explicit filing-context permission to use/view tax Documents/facts for preparation. Not: permanent Household sharing.

**Tax Classification Candidate** — potential tax treatment/category requiring verification. Not: final tax advice/decision.

## Privacy, search and integrations

**Visibility Policy** — rules for detail visibility, aggregate inclusion, Household calculation use, Tax Filing Context use, and mutation permission. Not: ownership.

**External Connection** — configured external provider link with authentication method, credential reference, granted scopes/capabilities, owner, and health. Not: OAuth token alone.

**External Capability** — permitted provider function such as Bank Data, Mail Read, Mail Send, Cloud Storage, Market Data, AI Inference, or Notification Delivery. Not: provider name.

**Alert** — actionable/informational product event such as cash-flow risk, sync failure, anomaly, missing tax document, or backup issue. Not: delivery channel.

**Notification Delivery** — mechanism that delivers an Alert/Insight in-app, push, email, or future adapter. Not: Alert itself.

**Scheduled Insight** — recurring authorized analytical job that produces an Insight/Alert and then uses normal delivery preferences. Not: unrestricted background AI.

**AI Provider** — configured local or remote inference provider behind Pryvance's bounded/redacted interface. Not: source of financial truth.

## Backup and recovery

**Backup Set** — point-in-time recoverable collection of database snapshot, referenced immutable objects, and verification manifest. Not: database dump alone.

**Backup Envelope** — authenticated encrypted artifact produced locally from a Backup Set before offsite storage. Not: cloud folder.

**Backup Destination** — replaceable offsite/secondary storage target that stores opaque Backup Envelopes, such as Google Drive or S3-compatible storage. Not: Recovery Secret holder.

**Recovery Secret** — independently stored secret material required to decrypt Backup Envelopes after host loss. Not: provider credential, login password.
